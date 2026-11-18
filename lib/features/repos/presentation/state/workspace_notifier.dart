import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/error/result.dart';

class WorkspaceState {
  /// Rutas de los repos abiertos, una por pestaña.
  final List<String> tabs;
  final int activeIndex;
  final bool isLoading;

  const WorkspaceState({this.tabs = const [], this.activeIndex = 0, this.isLoading = false});

  String? get activePath => tabs.isEmpty ? null : tabs[activeIndex.clamp(0, tabs.length - 1)];
}

/// Pestañas de proyectos abiertas por una cuenta (argumento: accountId).
final workspaceNotifierProvider =
    NotifierProvider.family<WorkspaceNotifier, WorkspaceState, String>(WorkspaceNotifier.new);

class WorkspaceNotifier extends Notifier<WorkspaceState> {
  final String accountId;

  WorkspaceNotifier(this.accountId);

  @override
  WorkspaceState build() {
    Future.microtask(_load);
    return const WorkspaceState(isLoading: true);
  }

  Future<void> _load() async {
    final saved = await ref.read(workspaceRepositoryProvider).load(accountId);
    final existing = <String>[];
    for (final path in saved.tabs) {
      if (await Directory(path).exists()) existing.add(path);
    }
    if (!ref.mounted) return;
    state = WorkspaceState(
      tabs: existing,
      activeIndex: saved.activeIndex.clamp(0, existing.isEmpty ? 0 : existing.length - 1),
    );
  }

  /// Abre (o activa, si ya estaba abierto) el repo que contiene [path].
  Future<AppFailure?> open(String path) async {
    final result = await ref.read(gitRepositoryProvider).resolveRepoRoot(path);
    switch (result) {
      case Failure(:final failure):
        return failure;
      case Success(value: final root):
        if (!ref.mounted) return null;
        final index = state.tabs.indexOf(root);
        if (index != -1) {
          activate(index);
        } else {
          _set([...state.tabs, root], state.tabs.length);
        }
        return null;
    }
  }

  void activate(int index) {
    if (index < 0 || index >= state.tabs.length) return;
    _set(state.tabs, index);
  }

  void close(int index) {
    if (index < 0 || index >= state.tabs.length) return;
    final tabs = [...state.tabs]..removeAt(index);
    var active = state.activeIndex;
    if (index < active || active >= tabs.length) active--;
    _set(tabs, active.clamp(0, tabs.isEmpty ? 0 : tabs.length - 1));
  }

  void _set(List<String> tabs, int active) {
    state = WorkspaceState(tabs: tabs, activeIndex: active);
    ref.read(workspaceRepositoryProvider).save(accountId, tabs, active);
  }
}
